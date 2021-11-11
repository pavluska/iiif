require 'net/https'
require 'open-uri'
require 'nokogiri'
require 'json'
require 'typhoeus'
require 'fastimage'

# @uuid = ARGV[0]
if ARGV.length == 1
    @link = ARGV[0]
    @library = @link.split("/")[3]
    object = @link.split("/")[5]
    @uuid = object.split("?")[0]
else 
    @library = ARGV[0]
    @uuid = ARGV[1]
end
@registrkrameriu = "https://registr.digitalniknihovna.cz/libraries.json"
@url_manifest = "https://api.pavlarychtarova.cz/iiif"
@mods
@canvasIndex = 0

@languages = {"cze" => "čeština", "ger" => "němčina", "eng" => "angličtina", "lat" => "latina", "fre" => "francouzština",
              "rus" => "ruština", "pol" => "polština", "slv" => "slovinština", "slo" => "slovenština", 
              "ita" => "italština", "dut" => "nizozemština",
              "und" => "neurčený jazyk", "zxx" => "žádný lingvistický obsah"}
@api = {
    "mzk" => "https://kramerius.mzk.cz", 
    "nkp" => "https://kramerius5.nkp.cz", 
    "mlp" => "https://kramerius4.mlp.cz", 
    "knav" => "https://kramerius.lib.cas.cz"
}

def get_xml(url)
    uri = URI(url) 
    # uri = URI(URI.encode(url))
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    https.verify_mode = OpenSSL::SSL::VERIFY_PEER
    https.open_timeout = 100
    https.read_timeout = 100
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = 'application/xml'
    response = https.request(request).read_body
    # begin
    #     response = https.request(request).read_body
    #     return response
    # rescue
    #     if run == 0
    #         return nil
    #     else
    #         get_xml(url, run - 1) 
    #     end
    # end
end

def get_json(url)
    uri = URI(url) #uri = URI(URI.encode(url))
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    request = Net::HTTP::Get.new(uri)
    request.add_field "Content-Type", "application/json; charset=utf-8"
    request.add_field "Accept", "application/json"
    response = https.request(request)

    result =  JSON.parse(response.read_body)
    return result
end

def control_404(url)
    response = Net::HTTP.get_response(URI(url))
    error = response.is_a?(Net::HTTPNotFound)
    code = response.code
    if code.to_i > 400
        result = true
    end
    return !result
end

def find_document_model(pid)
    document = {}
    uuid = "#{@uuid}".to_json
    @kramerius = create_provider(@library)[1]
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,fedora.model,root_title,details,title&q=PID:#{uuid}&rows=1500&start=0")
    response_body = object["response"]["docs"]
    document["model"] = response_body[0]["fedora.model"]
    document["root_title"] = response_body[0]["root_title"].split(":")[0]
    document["title"] = response_body[0]["title"]
    if document["model"].to_s == "periodicalvolume"
        if !response_body[0]["details"][0].split("##")[0].nil?
            document["date"] = response_body[0]["details"][0].split("##")[0].strip.sub(" ", "")
        end
        if !response_body[0]["details"][0].split("##")[1].nil?
            document["number"] = response_body[0]["details"][0].split("##")[1].strip.sub(" ", "")
        end  
    end
    if document["model"].to_s == "periodicalitem"
        if !response_body[0]["details"][0].split("##")[2].nil?
            document["date"] = response_body[0]["details"][0].split("##")[2].strip.sub(" ", "")
        end
        if !response_body[0]["details"][0].split("##")[3].nil?
            document["number"] = response_body[0]["details"][0].split("##")[3].strip.sub(" ", "")
        end  
    end
    return document
end

def mods_extractor
    errors = []
    mods = {}
    xmldoc = Nokogiri::XML get_xml("#{@kramerius}/search/api/v5.0/item/#{@uuid}/streams/BIBLIO_MODS")
        if xmldoc.nil? 
            errors << uuid
            continue
        end

    xmldoc.remove_namespaces!

    # sysno a sigla
    xmldoc.xpath("modsCollection/mods/recordInfo/recordIdentifier").each do |sys|
        sysno = "#{sys.text}"
        sigla = "MZK01"  #TODO
        if sysno.length == 9
            mods["sysno"] = sysno    
        end
        mods["sigla"] = sigla
    end

    # uuid
    xmldoc.xpath("modsCollection/mods/identifier").each do |id|
        if id.at("@type").to_s == "uuid"
            uuid = id.text
            if uuid.length == 36
                uuid = "uuid:#{id.text}"
            else
                uuid = "#{id.text}"
            end
            uuid2 = uuid.to_s
            mods["uuid"] = uuid2
        end

    end

    # title
    xmldoc.xpath("modsCollection/mods/titleInfo[1]").each do |titleInfo|
        if !titleInfo.at("title").nil?
            title = titleInfo.at("title").text
            if !titleInfo.at("nonSort").nil?
                nonsort = titleInfo.at("nonSort").text
                mods["title"] = "#{nonsort}#{title}"
            else
                mods["title"] = title
            end
        end
        if !titleInfo.at("subTitle").nil?
            subtitle = titleInfo.at("subTitle").text
            mods["subtitle"] = subtitle
        end
        if !titleInfo.at("partNumber").nil?
            partNumber = titleInfo.at("partNumber").text
            mods["partNumber"] = partNumber
        end
        if !titleInfo.at("partName").nil?
            partName = titleInfo.at("partName").text
            mods["partName"] = partName
        end
    end

    # authors
    if xmldoc.at("modsCollection/mods/name")
        authors = []
        xmldoc.xpath("modsCollection/mods/name").each do |name|
            author = ""
            if name.at("//namePart/@type").to_s == "family"
                family = ""
                given = ""
                termOfAddress = ""
                date = ""
                name.xpath("namePart").each do |namePart|
                    if namePart.at("@type").to_s == "family"
                        family = namePart.text
                    end
                    if namePart.at("@type").to_s == "given"
                        given = ", #{namePart.text}"
                    end
                    if namePart.at("@type").to_s == "termsOfAddress"
                        termOfAddress = ", #{namePart.text}"
                    end
                    if namePart.at("@type").to_s == "date"
                        date = ", #{namePart.text}"
                    end
                end
                author = "#{family}#{given}#{termOfAddress}#{date}"
            end          
            if name.at("//namePart[not(@type)]")
                name2 = ""
                termOfAddress = ""
                date = ""
                name.xpath("namePart").each do |namePart|
                    if namePart.at("@type").to_s == "termsOfAddress"
                        termOfAddress = ", #{namePart.text}"
                    elsif namePart.at("@type").to_s == "date"
                        date = ", #{namePart.text}"
                    # elsif namePart.at("[not(@type)]")
                    else
                        name2 = namePart.text
                    end   
                end
                author = "#{name2}#{termOfAddress}#{date}"
            end

            authors.push(author)
            mods["authors"] = authors
        end
    end

    # nakladatelske udaje
    xmldoc.xpath("modsCollection/mods/originInfo").each do |originInfo|
    published = ""    
        # place
        originInfo.xpath("place").each do |place|
            if place.xpath("placeTerm/@authority").to_s != "marccountry"
                places = place.at("placeTerm").text
                published = "#{published}#{places}"
            # else
            #     places = place.at("placeTerm").text
            #     published = "#{published}#{places}"
            end
        end
        
        # publisher
        if !originInfo.xpath("publisher").nil?
            originInfo.xpath("publisher").each do |pub|
                publisher = pub.text
                published = "#{published}: #{publisher}"
            end
        end

        # date
        if !originInfo.xpath("dateIssued").nil?
            dates = {}
            originInfo.xpath("dateIssued").each do |dat|
                if dat.at("@point").to_s == "start"
                    dates["date_start"] = dat.text
                elsif dat.at("@point").to_s == "end"
                    dates["date_end"] = dat.text
                else
                    dates["date"] = dat.text
                    mods["date"] = dat.text
                end
            end
            if published.length > 0
                published = "#{published}, #{dates["date"]}"
            else
                published = "#{dates["date"]}"
            end
        end
        mods["published"] = published
    end
    # jazyk
    langs = []
    xmldoc.xpath("modsCollection/mods/language/languageTerm").each do |lang|
        if !@languages[lang.text].nil?
            langs.push(@languages[lang.text])
        else 
            langs.push(lang.text)
        end
        mods["languages"] = langs
    end
    # coordinates
    xmldoc.xpath("modsCollection/mods/subject/cartographics/coordinates").each do |c|
        mods["coordinates"] = c.text
    end
    return mods
end

def create_label(uuid)
    label = {}
    if @document_model == "periodicalvolume" || @document_model == "periodicalitem"
        partDate = @mods["date"]
        label = {"none" => ["#{@root_title} (#{@document["date"]})"]}
    elsif @document_model == "soundunit"
            label = {"none" => ["#{@root_title} (#{@mods["partName"]})"]}
    else label = {"cz" => [@mods["title"]]}
    end
    return label
end

def create_metadata
    metadata = []
    if !@mods["title"].nil?
        title = {"label" => {"cz" => ["Název"]}, "value" => {"none" => [@mods["title"]]}}
        metadata.push(title)
    end
    if !@mods["subtitle"].nil?
        subtitle = {"label" => {"cz" => ["Podnázev"]}, "value" => {"none" => [@mods["subtitle"]]}}
        metadata.push(subtitle)
    end
    if !@type_of_resource.nil?
        type_of_resource = {"label" => {"cz" => ["Typ dokumentu"]}, "value" => {"cz" => [@type_of_resource]}}
        metadata.push(type_of_resource)
    end
    # if !@mods["partNumber"].nil?
    #     title = {"label" => {"cz" => ["Číslo části"]}, "value" => {"none" => [@mods["partNumber"]]}}
    #     metadata.push(title)
    # end
    if !@mods["authors"].nil?
        author = {"label" => {"cz" => ["Autor"]}, "value" => {"none" => [@mods["authors"]]}}
        metadata.push(author)
    end
    if @document_model == "periodicalvolume" || @document_model == "periodicalitem"
        number = {"label" => {"cz" => ["Číslo části"]}, "value" => {"none" => [@document["number"]]}}
        date = {"label" => {"cz" => ["Vydáno"]}, "value" => {"none" => [@document["date"]]}}
        metadata.push(number)
        metadata.push(date)
    elsif @document_model == "soundunit"
        number = {"label" => {"cz" => ["Číslo části"]}, "value" => {"none" => [@mods["partNumber"]]}}
        name = {"label" => {"cz" => ["Název části"]}, "value" => {"none" => [@mods["partName"]]}}
        metadata.push(number)
        metadata.push(name)
    elsif @mods["published"].length > 0
        published = {"label" => {"cz" => ["Nakladatelské údaje"]}, "value" => {"none" => [@mods["published"]]}}
        metadata.push(published)
    end
    if !@mods["languages"].nil?
        subtitle = {"label" => {"cz" => ["Jazyk"]}, "value" => {"none" => [@mods["languages"]]}}
        metadata.push(subtitle)
    end
    # return JSON.pretty_generate(metadata)
    return metadata
end

def create_provider(library)
    object = get_json("https://registr.digitalniknihovna.cz/libraries.json")
    id = object.find {|h1| h1['code'] == library}["library_url"]
    # id = object[0]["library_url"]
    label_cz = object.find {|h1| h1['code'] == library}["name"]
    label_en = object.find {|h1| h1['code'] == library}["name_en"]
    homepage = object.find {|h1| h1['code'] == library}["url"]
    logo = object.find {|h1| h1['code'] == library}["logo"]
    provider = [{"id" => id, "type" => "Agent", "label" => {"cz" => [label_cz]}, "homepage" => [{ "id" => homepage, "type" => "Text", "label" => {"cz" => [label_cz]}, "format" => "text/html"}], "logo" => [{"id" => logo, "type" => "Image", "format" => "image/png"}]}]
    return [provider, homepage]
end

def create_homepage
    uuid = @uuid
    sysno = @mods["sysno"]
    sigla = @mods["sigla"]
    homepage = []
    if !uuid.nil?
        dk = {"id" => "https://www.digitalniknihovna.cz/#{@library}/uuid/#{uuid}", "type" => "Text", "label" => { "cz" => ["Odkaz do Digitální knihovny"]}}
        homepage.push(dk)
    end
    if @library == "mzk"
        if !sysno.nil?
            vufind = {"id" => "https://vufind.mzk.cz/Record/#{sigla}-#{sysno}", "type" => "Text", "label" => { "cz" => ["Odkaz do Vufindu"]}}
            homepage.push(vufind)
        end
    end
    return homepage
end
def create_homepage_periodical_volume_issue
    uuid = @uuid
    homepage = []
    if !uuid.nil?
        dk = {"id" => "https://www.digitalniknihovna.cz/mzk/uuid/#{uuid}", "type" => "Text", "label" => { "cz" => ["Odkaz do Digitální knihovny"]}}
        homepage.push(dk)
    end
    return homepage
end

def create_behavior
    behavior = ["paged"]
    return behavior
end

def create_thumbnail(uuid)
    # https://kramerius.mzk.cz/search/api/v5.0/item/uuid:bdc28360-3fc8-11e7-b3c8-005056825209/thumb
    thumbnail = {"id" => "#{@kramerius}/search/api/v5.0/item/#{@uuid}/thumb",
                 "type" => "Image",
                 "format" => "image/jpeg",
                #  "service" => [{"@id" => "#{@kramerius}/search/iiif/#{@uuid}",
                #                "@type" => "ImageService2",
                #                "profile" => "http://iiif.io/api/image/2/level2.json"
                #               }]
                }
    return [thumbnail]
end

def create_navPlace
    type = "Polygon"
    coordinates = parse_coordinates
    features = {
        "id" => "#{@url_manifest}/#{@library}/#{@uuid}/feature/1",
        "type" => "Feature",
        "properties" => {
            "label" => {"en" => [@title]}
        },
        "geometry" => {
            "type" => type,
            "coordinates" => [coordinates]
        }
    }
    navPlace = {
        "id" => "#{@url_manifest}/#{@library}/#{@uuid}/feature",
        "type" => "FeatureCollection",
        "features" => [features]
    }
    return navPlace
end
def parse_coordinates
    input = @mods["coordinates"]
    reg1 = "^\\((\\d{1,3})°(\\d{1,2})\´(\\d{1,2})\"\\s([v,z]{1})\.d\.--(\\d{1,3})°(\\d{1,2})\´(\\d{1,2})\"\\s([v,z]{1})\.d\.\/(\\d{1,3})°(\\d{1,2})\´(\\d{1,2})\"\\s([s,j]{1})\.š\.--(\\d{1,3})°(\\d{1,2})\´(\\d{1,2})\"\\s([s,j]{1})\.š\.\\)$"
    reg2 = "^\\(([E,W]{1})\\s(\\d{1,3})°(\\d{1,2})'(\\d{1,2})\"--([E,W]{1})\\s(\\d{1,3})°(\\d{1,2})'(\\d{1,2})\"\/([S,N]{1})\\s(\\d{1,3})°(\\d{1,2})'(\\d{1,2})\"--([S,N]{1})\\s(\\d{1,3})°(\\d{1,2})'(\\d{1,2})\"\\)$"
    output = input.match(reg1)
    output2 = input.match(reg2)
    # d1s1 d2s1
    # d1s2 d2s2
    if !output.nil?
        d1x = output[4]
        d1 = (output[1].to_f + (output[2].to_f/60) + (output[3].to_f/3600))
        d2x = output[8]
        d2 = (output[5].to_f + (output[6].to_f/60) + (output[7].to_f/3600))
        s1x = output[12]
        s1 = (output[9].to_f + (output[10].to_f/60) + (output[11].to_f/3600))
        s2x = output[16]
        s2 = (output[13].to_f + (output[14].to_f/60) + (output[14].to_f/3600))
        if d1x == "z"
            d1 = d1*-1
        end
        if d2x == "z"
            d2 = d2*-1
        end
        if s1x == "j"
            s1 = s1*-1
        end
        if s2x == "j"
            s2 = s2*-1
        end
        coordinates = [[d1, s1], [d2, s1], [d1, s2], [d2, s2]]
    elsif !output2.nil?
        d1x = output2[1]
        d1 = (output2[2].to_f + (output2[3].to_f/60) + (output2[4].to_f/3600))
        d2x = output2[5]
        d2 = (output2[6].to_f + (output2[7].to_f/60) + (output2[8].to_f/3600))
        s1x = output2[9]
        s1 = (output2[10].to_f + (output2[11].to_f/60) + (output2[12].to_f/3600))
        s2x = output2[13]
        s2 = (output2[14].to_f + (output2[15].to_f/60) + (output2[16].to_f/3600))
        if d1x == "W"
            d1 = d1*-1
        elsif d2x == "W"
            d2 = d2*-1
        elsif s1x == "S"
            s1 = s1*-1
        elsif s2x == "S"
            s2 = s2*-1
        end
        coordinates = [[d1, s1], [d2, s1], [d1, s2], [d2, s2]]
    end
    return coordinates
end

def create_list_of_pages(uuid)
    # nactu a seradim si stranky    
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,details,rels_ext_index&q=parent_pid:#{uuid} AND fedora.model:page&rows=1500&start=0")
    response_body = object["response"]["docs"]
    sorted_object = response_body.sort { |a, b| a["rels_ext_index"] <=> b["rels_ext_index"]}
    pids = []
    pages = []
    
    # pro kazdou stranku:
    sorted_object.each do |page|
        page_properties = {}
        uuid_page = page["PID"]
        pids.push(uuid_page)
        page_properties["pid"] = uuid_page
        index = @canvasIndex

        # id pro vsechny urovne
        page_properties["canvas_id"] = "#{@url_manifest}/#{@library}/#{@uuid}/canvases/#{index}"
        page_properties["annotationPage_id"] = "#{@url_manifest}/#{@library}/#{@uuid}/canvases/#{index}/ap"
        page_properties["annotation_id"] = "#{@url_manifest}/#{@library}/#{@uuid}/canvases/#{index}/ap/a"
        page_properties["body_id_iiif"] = "#{@kramerius}/search/iiif/#{uuid_page}/full/full/0/default.jpg"
        page_properties["body_id_imgfull"] = "#{@kramerius}/search/api/v5.0/item/#{uuid_page}/streams/IMG_FULL"
        page_properties["alto_id"] = "#{@kramerius}/search/api/v5.0/item/#{uuid_page}/streams/ALTO"
        page_properties["thumb_id"] = "#{@kramerius}/search/api/v5.0/item/#{uuid_page}/thumb"

        # cislo strany
        canvas_label = ""
        if !page["details"][0].split("##")[0].nil?
            page_properties["page_number"] = page["details"][0].split("##")[0].strip.sub(" ", "")
        end
        
        # typ strany
        page_type = ""
        if !page["details"][0].split("##")[1].nil?
            page_properties["page_type"] = page["details"][0].split("##")[1].strip.sub(" ", "")
        end
        pages.push(page_properties)
        @canvasIndex += 1
    end

    if !pages[0].nil?
        @image_iiif = control_404("#{@kramerius}/search/iiif/#{pages[0]['pid']}/info.json")
    end

    # typhoeus test
    if @image_iiif
        hydra = Typhoeus::Hydra.new
        requests = pids.map{ |pid|
            request = Typhoeus::Request.new( 
            "#{@kramerius}/search/iiif/#{pid}/info.json",
            method: :get,
            headers: {
                "Content-Type" => "application/json"
            },
            followlocation: true
            )
            hydra.queue(request)
            request
        }
        hydra.run
        responses = requests.map { |request|
            JSON(request.response.body) if request.response.code === 200
        }

        pages.each do |page|
            pid2 = "#{@kramerius}/search/iiif/#{page["pid"]}"
            if !responses.nil?
                responses.each do |item|
                    if !item["@id"].nil?
                        if pid2 === item["@id"]
                            page["max_width"] = item["width"]
                            page["max_height"] = item["height"]
                            page["thumb_width"] = item["sizes"][0]["width"]
                            page["thumb_height"] = item["sizes"][0]["height"]
                            page["width"] = item["sizes"][item["sizes"].length - 1]["width"]
                            page["height"] = item["sizes"][item["sizes"].length - 1]["height"]
                        end
                    end
                end
            end
        end
    else
        pages.each do |page|
            if !page["body_id_imgfull"].nil?
                size = FastImage.size(page["body_id_imgfull"])
                page["width"] = size[0]
                page["height"] = size[1]
                page["thumb_width"] = size[0].to_i/10
                page["thumb_height"] = size[1].to_i/10
            end
        end
    end
    return pages
end

def create_items_pages(uuid)
    uuid = uuid.to_json
    itemsCanvas = []
    pages = create_list_of_pages(uuid)
    if !pages[0].nil?
        alto = control_404("#{@kramerius}/search/api/v5.0/item/#{pages[0]['pid']}/streams/ALTO")
    end
    pages.each do |page|
        itemsAnnotationPage = []
        itemsAnnotation = []
        seeAlso = {"id" => page["alto_id"], 
                "type" => "Alto", 
                "profile" => "https://www.loc.gov/standards/alto/v3/alto.xsd", 
                "label" => { "none" => ["ALTO XML"] }, 
                "format" => "text/xml"}
        body_service = {"@id" => "#{@kramerius}/search/iiif/#{page["pid"]}",
                        "@type" => "ImageService2",
                        "profile" => "http://iiif.io/api/image/2/level1.json",
                        # "width" => "",
                        # "height" => ""
                        }
        # TODO thumb_service = {}
        canvas_thumbnail = {"id" => page["thumb_id"], 
                            "type" => "Image", 
                            "width" => page["thumb_width"], 
                            "height" => page["thumb_height"], 
                            # TODO "service" => [thumb_service]
                            }
        if @image_iiif 
            body = {"id" => page["body_id_iiif"], 
                "type" => "Image", 
                "width" => page["width"], 
                "height" => page["height"], 
                "format" => "image/jpeg", 
                "service" => [body_service]
                }
        else 
            body = {"id" => page["body_id_imgfull"], 
                "type" => "Image", 
                "width" => page["width"], 
                "height" => page["height"], 
                "format" => "image/jpeg", 
                }
        end
        annotation = {"id" => page["annotation_id"], 
                      "type" => "Annotation", 
                      "motivation" => "painting", 
                      "body" => body, 
                      "target" => page["canvas_id"]
                    }
        annotationPage = {"id" => page["annotationPage_id"], 
                          "type" => "AnnotationPage", 
                          "items" => itemsAnnotation
                        }
        if alto
            canvas = {"id" => page["canvas_id"], 
                      "type" => "Canvas", 
                      "label" => { "none" => [page["page_number"]]}, 
                      "width" => page["width"], 
                      "height" => page["height"], 
                      "thumbnail" => [canvas_thumbnail], 
                      "seeAlso" => [seeAlso], 
                      "items" => itemsAnnotationPage
                    }
        else
            canvas = {"id" => page["canvas_id"], 
                "type" => "Canvas", 
                "label" => { "none" => [page["page_number"]]}, 
                "width" => page["width"], 
                "height" => page["height"], 
                "thumbnail" => [canvas_thumbnail],  
                "items" => itemsAnnotationPage
            }
        end
        itemsAnnotation.push(annotation)
        itemsAnnotationPage.push(annotationPage)
        itemsCanvas.push(canvas)
    end
    return itemsCanvas
end

def create_list_of_mp3(uuid)
    # TODO DURATION AZ OD VERZE API K7
    uuid2 = uuid.to_json
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,details,rels_ext_index,title&q=parent_pid:#{uuid2} AND fedora.model:track&rows=1500&start=0")
    response_body = object["response"]["docs"]
    tracks = []
    
    response_body.each do |track|
        index = @canvasIndex
        track_properties = {}
        track_properties["title"] = track["title"]
        track_properties["uuid"] = track["PID"]
        # TODO track_properties["duration"] = 
        track_properties["duration"] = 1234.0
        track_properties["thumb_id"] = "#{@kramerius}/search/api/v5.0/item/#{uuid}/thumb"
        track_properties["body_id"] = "#{@kramerius}/search/api/v5.0/item/#{track["PID"]}/streams/MP3"
        track_properties["canvas_id"] = "#{@url_manifest}/#{@library}/#{@uuid}/canvases/#{index}"
        track_properties["annotationPage_id"] = "#{@url_manifest}/#{@library}/#{@uuid}/canvases/#{index}/ap"
        track_properties["annotation_id"] = "#{@url_manifest}/#{@library}/#{@uuid}/canvases/#{index}/ap/a"
        @canvasIndex += 1
        tracks.push(track_properties)     
    end   
    return tracks
end

def create_items_tracks(uuid)
    itemsCanvas = []
    tracks = create_list_of_mp3(uuid)
    tracks.each do |track|
        itemsAnnotationPage = []
        itemsAnnotation = []
        track_thumbnail = {"id" => track["thumb_id"],
                            "type" => "Image",
                            "format" => "image/jpeg"
                            }
        body = {"id" => track["body_id"], 
            "type" => "Sound", 
            #TODO "duration" => track["duration"],
            "duration" => track["duration"],
            "format" => "audio/mp3", 
            #TODO "service" => [body_service]
            }
        annotation = {"id" => track["annotation_id"], 
            "type" => "Annotation", 
            "motivation" => "painting", 
            "body" => body, 
            "target" => track["canvas_id"]
        }
        annotationPage = {"id" => track["annotationPage_id"], 
            "type" => "AnnotationPage", 
            "items" => itemsAnnotation
        }
        canvas = {"id" => track["canvas_id"], 
            "type" => "Canvas", 
            "label" => { "none" => [track["title"]]},
            "duration" => track["duration"],
            "thumbnail" => [track_thumbnail], 
            # "seeAlso" => [seeAlso], 
            "items" => itemsAnnotationPage
        }
        itemsAnnotation.push(annotation)
        itemsAnnotationPage.push(annotationPage)
        itemsCanvas.push(canvas)
    end
    return itemsCanvas
end

def part_of
    uuid = "#{@uuid}".to_json
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=parent_pid,collection&rows=1500&start=0&q=PID:#{uuid}")
    response_body = object["response"]["docs"]

    partOf = []

    response_body.each do |a|
        a["parent_pid"].each do |pid|
            item = {}
            uuid = pid.to_json
            object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,title,root_title,fedora.model&rows=1500&start=0&q=PID:#{uuid}")
            response_body = object["response"]["docs"][0]
            if response_body["fedora.model"] == "periodical" || response_body["fedora.model"] == "periodicalvolume" || response_body["fedora.model"] == "soundrecording"
                item["id"] = "#{@url_manifest}/#{@library}/#{pid}"
                item["type"] = "Collection"
                item["label"] = response_body["root_title"]
            end
            partOf.push(item)
        end
        # VYPRDNOUT SE NA KOLEKCE VE VERZI 5
        # a["collection"].each do |vc|
        #     item = {}
        #     item["id"] = "#{@url_manifest}/#{vc}"
        #     item["type"] = "Collection"
        #     # ZISKAT NAZEV KOLEKCE - HROZNE TO TRVA
        #     # object = get_json("https://kramerius.mzk.cz/search/api/v5.0/vc")
        #     # object.each do |collection|
        #     #     if collection["pid"] == vc
        #     #         item["label"] = collection["descs"]["cs"]
        #     #     end
        #     # end
        #     partOf.push(item)
        # end
    end
    return partOf
end

# ---------- MONOGRAFIE -----------
def create_iiif_monograph
    if !@mods["coordinates"].nil?
        context = ["http://iiif.io/api/extension/navplace/context.json", "http://iiif.io/api/presentation/3/context.json"]
        iiif = {"@context" => context, 
            "id" => "#{@url_manifest}/#{@library}/#{@uuid}", 
            "type" => "Manifest", 
            "label" => create_label(@uuid), 
            "metadata" => create_metadata, 
            # "behavior" => create_behavior, 
            "provider" => create_provider(@library)[0], 
            "homepage" => create_homepage,
            "thumbnail" => create_thumbnail(@uuid),
            "navPlace" => create_navPlace,
            "items" => create_items_pages(@uuid)
        }
    else
        context = "https://iiif.io/api/presentation/3/context.json"
        iiif = {"@context" => context, 
            "id" => "#{@url_manifest}/#{@library}/#{@uuid}", 
            "type" => "Manifest", 
            "label" => create_label(@uuid), 
            "metadata" => create_metadata, 
            # "behavior" => create_behavior, 
            "provider" => create_provider(@library)[0], 
            "homepage" => create_homepage,
            "thumbnail" => create_thumbnail(@uuid),
            "items" => create_items_pages(@uuid)
        }
    end
    return JSON.pretty_generate(iiif)
end
# ---------- KONEC MONOGRAFIE -----------

# ---------- CISLO PERIODIKA -----------

def create_iiif_periodicalissue
    iiif = {"@context" => "https://iiif.io/api/presentation/3/context.json", 
                "id" => "#{@url_manifest}/#{@library}/#{@uuid}", 
                "type" => "Manifest", 
                "label" => create_label(@uuid), 
                "metadata" => create_metadata, 
                "provider" => create_provider(@library)[0],
                "homepage" => create_homepage_periodical_volume_issue,
                "thumbnail" => create_thumbnail(@uuid),
                "items" => create_items_pages(@uuid),
                "partOf" => part_of
            }
    return JSON.pretty_generate(iiif)
end
# ---------- KONEC CISLO PERIODIKA -----------

# ---------- ROCNIK PERIODIKA -----------

def create_iiif_periodicalvolume
    iiif = {"@context" => "https://iiif.io/api/presentation/3/context.json", 
                "id" => "#{@url_manifest}/#{@library}/#{@uuid}", 
                "type" => "Collection", 
                "label" => create_label(@uuid), 
                "metadata" => create_metadata, 
                "provider" => create_provider(@library)[0], 
                "homepage" => create_homepage_periodical_volume_issue,
                "thumbnail" => create_thumbnail(@uuid),
                "items" => create_items_periodical_issues,
                "partOf" => part_of
            }
    return JSON.pretty_generate(iiif)
end

def create_list_of_periodical_issues
    uuid = "#{@uuid}".to_json

    # najdu si cisla (items) a seradim   
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,details,rels_ext_index&q=parent_pid:#{uuid} AND fedora.model:periodicalitem&rows=1500&start=0")
    response_body = object["response"]["docs"]
    sorted_object = response_body.sort { |a, b| a["rels_ext_index"] <=> b["rels_ext_index"]}
    
    periodicalissues = []

    sorted_object.each do |issue|
        issue_properties = {}
        issue_properties["index"] = issue["rels_ext_index"][0]
        issue_properties["pid"] = issue["PID"]    
        # datum vydani cisla
        issue_date = ""
        if !issue["details"][0].split("##")[0].nil?
            issue_properties["issue_date"] = issue["details"][0].split("##")[2].strip.sub(" ", "")
        end  
        # cislo cisla
        issue_number = ""
        if !issue["details"][0].split("##")[1].nil?
            issue_properties["issue_number"] = issue["details"][0].split("##")[3].strip.sub(" ", "")
        end
        periodicalissues.push(issue_properties)
    end
    return periodicalissues
end

def create_items_periodical_issues
    itemsIssues = []
    issues = create_list_of_periodical_issues

    issues.each do |issue|
        item = {"id" => "#{@url_manifest}/#{@library}/#{issue["pid"]}",
                "type" => "Manifest",
                "label" => "#{@root_title} (#{issue["issue_date"]})"
               }
        itemsIssues.push(item)
    end
    return itemsIssues
end

# ---------- KONEC ROCNIK PERIODIKA -----------

# ---------- TITUL PERIODIKA -----------
def create_iiif_periodical
    iiif = {"@context" => "https://iiif.io/api/presentation/3/context.json",
                "id" => "#{@url_manifest}/#{@library}/#{@uuid}", 
                "type" => "Collection", 
                "label" => create_label(@uuid), 
                "metadata" => create_metadata, 
                "provider" => create_provider(@library)[0], 
                "homepage" => create_homepage,
                "thumbnail" => create_thumbnail(@uuid),
                "items" => create_items_periodical_volumes
            }
    return JSON.pretty_generate(iiif)
end
def create_list_of_periodical_volumes
    uuid = "#{@uuid}".to_json

    # najdu si rocniky a seradim   
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,details,rels_ext_index&q=parent_pid:#{uuid} AND fedora.model:periodicalvolume&rows=1500&start=0")
    response_body = object["response"]["docs"]
    sorted_object = response_body.sort { |a, b| a["rels_ext_index"] <=> b["rels_ext_index"]}
    
    periodicalvolumes = []

    sorted_object.each do |volume|
        volume_properties = {}
        index = volume["rels_ext_index"][0]
        uuid_volume = volume["PID"]
        # pids.push(uuid_volume)
        volume_properties["index"] = index
        volume_properties["pid"] = uuid_volume
        # cislo rocniku
        volume_date = ""
        if !volume["details"][0].split("##")[0].nil?
            volume_properties["volume_date"] = volume["details"][0].split("##")[0].strip.sub(" ", "")
        end  
        # rok vydani rocniku
        volume_number = ""
        if !volume["details"][0].split("##")[1].nil?
            volume_properties["volume_number"] = volume["details"][0].split("##")[1].strip.sub(" ", "")
        end
        periodicalvolumes.push(volume_properties)
    end
    return periodicalvolumes
end

def create_items_periodical_volumes
    itemsVolumes = []
    volumes = create_list_of_periodical_volumes
    volumes.each do |volume|
        item = {"id" => "#{@url_manifest}/#{@library}/#{volume["pid"]}",
                "type" => "Collection",
                "label" => volume["volume_date"]
               }
        itemsVolumes.push(item)
    end
    return itemsVolumes
end
# ---------- KONEC TITUL PERIODIKA -----------

# # ---------- SOUNDUNIT -----------
# def create_iiif_soundunit
#     iiif = {"@context" => "https://iiif.io/api/presentation/3/context.json", 
#                 "id" => "#{@url_manifest}/#{@library}/#{@uuid}", 
#                 "type" => "Manifest", 
#                 "label" => create_label(@uuid), 
#                 "metadata" => create_metadata, 
#                 "provider" => create_provider("BOA001"), 
#                 "homepage" => create_homepage_periodical_volume_issue,
#                 "thumbnail" => create_thumbnail(@uuid),
#                 "items" => create_items_tracks(@uuid),
#                 "partOf" => part_of
#             }
#     return JSON.pretty_generate(iiif)
# end
# # ---------- KONEC SOUNDUNIT -----------

# ---------- SOUNDRECORDING -----------
def create_iiif_soundrecording
    @soundrecordings = create_items_soundrecording
    iiif = {"@context" => "https://iiif.io/api/presentation/3/context.json",
                "id" => "#{@url_manifest}/#{@library}/#{@uuid}", 
                "type" => "Manifest", 
                "label" => create_label(@uuid), 
                "metadata" => create_metadata, 
                "provider" => create_provider(@library)[0], 
                "homepage" => create_homepage,
                "thumbnail" => create_thumbnail(@uuid),
                "items" => @soundrecordings[0],
                "structures" => @soundrecordings[1]
            }
    return JSON.pretty_generate(iiif)
end
def create_items_soundrecording
    @rangeIndex = 0
    canvases = create_items_pages(@uuid)
    structures = []
    soundunits = create_list_of_soundunits
    soundunits.each do |soundunit|
        su_uuid = soundunit["pid"]
        index = @rangeIndex
        range_items = []
        # soundunit_pages = create_items_pages(su_uuid)
        # soundunit_pages.each do |page|
        #     canvases.push(page)
        #     range_canvas = {"id" => page["id"], "type" => page["type"]}
        #     range_items.push(range_canvas)
        # end
        soundunit_mp3s = create_items_tracks(su_uuid)
        soundunit_mp3s.each do |mp3|
            canvases.push(mp3)
            range_canvas = {"id" => mp3["id"], "type" => mp3["type"]}
            range_items.push(range_canvas)
        end
        range = {"id" => "#{@url_manifest}/#{@library}/#{@uuid}/range/#{index}",
                 "type" => "Range",
                 "label" => "#{soundunit["title"]}",
                 "items" => range_items
                }
        @rangeIndex += 1
        structures.push(range)
    end
    return [canvases, structures]
end
def create_list_of_soundunits
    uuid = "#{@uuid}".to_json
    object_soundunit = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,details,rels_ext_index,title&q=parent_pid:#{uuid} AND fedora.model:soundunit&rows=1500&start=0")
    soundunit_body = object_soundunit["response"]["docs"]
    # object_page = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,details,rels_ext_index,title&q=parent_pid:#{uuid} AND fedora.model:page&rows=1500&start=0")
    # page_body = object_page["response"]["docs"]
    soundunits = []
    soundunit_body.each do |soundunit|
        soundunit_properties = {}
        soundunit_properties["pid"] = soundunit["PID"]
        soundunit_properties["title"] = soundunit["title"]
        soundunits.push(soundunit_properties)
    end
    return soundunits
end

# ---------- KONEC SOUNDRECORDING -----------


def create_iiif
    @kramerius = create_provider(@library)[1]
    # @kramerius = @api["#{@library}"]
    @mods = mods_extractor
    @document = find_document_model(@uuid)
    @document_model = @document["model"]
    @root_title = @document["root_title"]
    @title = @document["title"]
    if @document_model == "monograph"
        @type_of_resource = "Monografie"
        puts create_iiif_monograph
    elsif @document_model == "map"
        @type_of_resource = "Mapa"
        puts create_iiif_monograph
    elsif @document_model == "graphic"
        @type_of_resource = "Grafika"
        puts create_iiif_monograph
    elsif @document_model == "sheetmusic"
        @type_of_resource = "Hudebnina"
        puts create_iiif_monograph
    elsif @document_model == "archive"
        @type_of_resource = "Archiválie"
        puts create_iiif_monograph
    elsif @document_model == "manuscript"
        @type_of_resource = "Rukopis"
        puts create_iiif_monograph
    elsif @document_model == "soundrecording"
        @type_of_resource = "Zvuková nahrávka"
        puts create_iiif_soundrecording
    elsif @document_model == "soundunit"
        @type_of_resource = "Zvuková nahrávka - část"
        puts "soundunit - negeneruje iiif"
    elsif @document_model == "periodical"
        @type_of_resource = "Periodikum"
        puts create_iiif_periodical
    elsif @document_model == "periodicalvolume"
        @type_of_resource = "Ročník periodika"
        puts create_iiif_periodicalvolume
    elsif @document_model == "periodicalitem"
        @type_of_resource = "Číslo periodika"
        puts create_iiif_periodicalissue
    else puts @document_model
    end
end


puts create_iiif

